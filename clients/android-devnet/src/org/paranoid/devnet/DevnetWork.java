package org.paranoid.devnet;
/** Keep optional Devnet module/linkage failures inside this worker, not the messenger.
 * Fatal VM failures are not swallowed; they cannot safely be recovered here.
 */
final class DevnetWork {
    interface Action { String run()throws Exception; }
    static String run(Action action) {
        try{return action.run();}
        catch(LinkageError unavailable){return "Раздел Devnet недоступен в этой сборке. Вернитесь в ParanoID: чаты и звонки не изменены.";}
        catch(Exception failure){
            String code=failure.getMessage();
            if("storage_frozen".equals(code)||"incomplete_retained_state".equals(code))return "Хранилище Devnet заблокировано после незавершённой записи. Чаты и звонки не затронуты. В этой версии нет безопасного сброса только Devnet. Не очищайте данные ParanoID: это удалит ID мессенджера и локальную переписку. Сообщите об ошибке; не переустанавливайте приложение.";
            if("insufficient_devnet_sol".equals(code))return "Недостаточно тестовых SOL. Нажмите «Получить тестовые SOL» или скопируйте публичный адрес для пополнения в Devnet. Реальные SOL не нужны.";
            if("rpc_rate_limit".equals(code)||"faucet_attempt_already_used".equals(code))return "Кран Devnet ограничил запрос или попытка уже использована. Не повторяем автоматически. Скопируйте публичный адрес для пополнения тестовыми SOL.";
            if("invalid_mnemonic".equals(code))return "Не удалось проверить 24 слова. Проверьте английские слова и их порядок. Не вводите фразу реального кошелька.";
            if("backup_confirmation_required".equals(code))return "Сначала сохраните 24 слова Devnet и подтвердите, что записали их.";
            if("identity_already_exists".equals(code))return "На этом телефоне уже есть Devnet-ключ. Его не заменяем и не удаляем; используйте проверку ника или показ слов.";
            if("different_name_pending".equals(code))return "Предыдущая регистрация ещё может подтвердиться. Пока нельзя выбрать другой ник — проверьте результат позже.";
            if("name_conflict_or_partial_record".equals(code))return "Ник занят либо записи не совпадают. Новый ник можно выбрать только после завершения или истечения предыдущей попытки. Сохранённый ключ не меняем.";
            return "Операция Devnet не завершена. Если транзакция уже отправлена, нажмите проверку ника. ("+failure.getClass().getSimpleName()+")";
        }
    }
}
